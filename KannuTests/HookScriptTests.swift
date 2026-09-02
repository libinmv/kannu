//
//  HookScriptTests.swift
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

/// Runs the hook script mirror (`scripts/kannu-agent-status.sh`) as a subprocess against a
/// throwaway status directory. Until now the script's read-modify-write protocol was only ever
/// measured by hand (the "11/200 lost urgent states" figure in CHANGELOG); these pin it.
///
/// The mirror is what `install-cursor-hooks.sh` ships and the pre-commit hook keeps it at the
/// same version as the copy embedded in `AgentHookInstaller`, so exercising the mirror covers
/// both. `HOME` is overridden because the shell wrapper derives `KANNU_STATUS_DIR` from it.
final class HookScriptTests: XCTestCase {

    private var home: URL!
    private var statusDir: URL { home.appendingPathComponent(".kannu/agent-status", isDirectory: true) }

    private static let scriptURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KannuTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("scripts/kannu-agent-status.sh")
    }()

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3")
                          || FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
                          || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/python3"),
                          "python3 not installed; the hook script's fast path is not under test")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.scriptURL.path),
                          "mirror script not found at \(Self.scriptURL.path)")
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-hook-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    // MARK: - Helpers

    /// Launches one hook invocation. Returns the process so callers can overlap several.
    @discardableResult
    private func launch(state: String, event: String, conversation: String, toolName: String = "Bash") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptURL.path, state, "claude", event]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        let payload = #"{"session_id":"\#(conversation)","tool_name":"\#(toolName)","hook_event_name":"\#(event)"}"#
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        return process
    }

    private func run(state: String, event: String, conversation: String) throws {
        let process = try launch(state: state, event: event, conversation: conversation)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "hook exited \(process.terminationStatus)")
    }

    private func statusFile(_ conversation: String) -> URL {
        statusDir.appendingPathComponent("claude-\(conversation).json")
    }

    private func readState(_ conversation: String) throws -> String? {
        let url = statusFile(conversation)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["state"] as? String
    }

    private func writeStatus(_ conversation: String, state: String, event: String, tsMs: Int64) throws {
        try FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["state": state, "ts": tsMs, "provider": "claude", "hook_event": event]
        try JSONSerialization.data(withJSONObject: obj).write(to: statusFile(conversation))
    }

    // MARK: - Tests

    func testExecutingDoesNotOverwriteFreshPermissionRequest() throws {
        try run(state: "awaiting_input", event: "PermissionRequest", conversation: "c1")
        XCTAssertEqual(try readState("c1"), "awaiting_input")
        try run(state: "executing", event: "PreToolUse", conversation: "c1")
        XCTAssertEqual(try readState("c1"), "awaiting_input",
                       "a parallel tool call's PreToolUse must not downgrade a permission prompt inside the 2s window")
    }

    func testExecutingReplacesStalePermissionRequest() throws {
        let staleTs = Int64(Date().timeIntervalSince1970 * 1000) - 5_000
        try writeStatus("c2", state: "awaiting_input", event: "PermissionRequest", tsMs: staleTs)
        try run(state: "executing", event: "PreToolUse", conversation: "c2")
        XCTAssertEqual(try readState("c2"), "executing",
                       "once the 2s arbitration window has passed the newer event wins")
    }

    func testCrossEventMergeIsLimitedToPermissionRequests() throws {
        // A generic `stopped` from Stop must still be replaced by a later PreToolUse — the
        // narrow carry applies to awaiting_input from PermissionRequest only.
        try run(state: "stopped", event: "Stop", conversation: "c3")
        try run(state: "executing", event: "PreToolUse", conversation: "c3")
        XCTAssertEqual(try readState("c3"), "executing")
    }

    func testSessionEndRemovesStatusFileAndKeepsDirectoryLock() throws {
        try run(state: "executing", event: "PreToolUse", conversation: "c4")
        XCTAssertNotNil(try readState("c4"))
        try run(state: "session_end", event: "SessionEnd", conversation: "c4")
        XCTAssertNil(try readState("c4"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: statusDir.appendingPathComponent(".kannu-status.lock").path),
                      "the directory lock must never be unlinked — a hook may hold or be about to open it")
    }

    func testParallelPermissionRequestAndPreToolUseNeverLoseTheUrgentState() throws {
        // The measured "11/200" race, sized for CI: two hooks for one conversation launched
        // back-to-back in either order must always leave the urgent state on disk.
        for round in 0..<20 {
            let conversation = "p\(round)"
            let first = round.isMultiple(of: 2)
                ? try launch(state: "awaiting_input", event: "PermissionRequest", conversation: conversation)
                : try launch(state: "executing", event: "PreToolUse", conversation: conversation)
            let second = round.isMultiple(of: 2)
                ? try launch(state: "executing", event: "PreToolUse", conversation: conversation)
                : try launch(state: "awaiting_input", event: "PermissionRequest", conversation: conversation)
            first.waitUntilExit()
            second.waitUntilExit()
            XCTAssertEqual(try readState(conversation), "awaiting_input", "round \(round) lost the urgent state")
        }
    }
}
