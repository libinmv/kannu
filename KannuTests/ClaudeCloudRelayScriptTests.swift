//
//  ClaudeCloudRelayScriptTests.swift
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

/// Runs the cloud relay script exactly as Kannu hands it out (`ClaudeCloudRelaySetup.scriptSource`)
/// with a fake `curl` first on PATH, which records every request instead of sending it. The script
/// runs in sessions Kannu cannot see, so these are the only place its rules are ever exercised:
/// what leaves the session, when it is sent, and that it never disturbs the session it runs in.
///
/// The environment is built from scratch, not inherited, so a developer running the suite inside a
/// cloud session (or with a relay key exported) gets the same results as CI.
final class ClaudeCloudRelayScriptTests: XCTestCase {

    private let secret = String(repeating: "0123456789abcdef", count: 4)
    private let session = "session_01AbCdEf"
    private var root: URL!
    private var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    private var calls: URL { root.appendingPathComponent("calls", isDirectory: true) }
    private var temporary: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    private var script: URL { root.appendingPathComponent("kannu-cloud-relay.sh") }
    private var stateFolder: URL { temporary.appendingPathComponent("kannu-cloud-relay-\(getuid())", isDirectory: true) }

    /// System Python first: the oldest interpreter the script is likely to meet, so a newer-only
    /// construct fails here rather than in someone's cloud session.
    private static let systemPath = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"

    private static let mirrorURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KannuTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("scripts/kannu-cloud-relay.sh")
    }()

    /// Records each request as `<n>.args` (one argument per line, the URL last) and `<n>.body`, then
    /// answers like curl's `-w %{http_code}`. `KANNU_FAKE_CURL_EXIT` fails the way an unreachable
    /// host does; the quota lookup `--check` makes gets a canned account answer.
    private static let fakeCurl = """
        #!/bin/bash
        for url in "$@"; do :; done
        case "$url" in
          */v1/account) printf '{"stats":{"messages_remaining":42}}'; exit 0 ;;
        esac
        i=0
        while [ -e "$KANNU_FAKE_CURL_DIR/$i.body" ]; do i=$((i+1)); done
        printf '%s\\n' "$@" > "$KANNU_FAKE_CURL_DIR/$i.args"
        cat > "$KANNU_FAKE_CURL_DIR/$i.body"
        if [ -n "${KANNU_FAKE_CURL_EXIT:-}" ]; then printf '000'; exit "$KANNU_FAKE_CURL_EXIT"; fi
        printf '%s' "${KANNU_FAKE_CURL_STATUS:-200}"

        """

    override func setUpWithError() throws {
        try XCTSkipUnless(["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
                            .contains { FileManager.default.isExecutableFile(atPath: $0) },
                          "python3 not installed; the relay script needs it")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kannu-cloud-relay-tests-\(UUID().uuidString)", isDirectory: true)
        for folder in [bin, calls, temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try write(Self.fakeCurl, to: bin.appendingPathComponent("curl"), executable: true)
        try write(ClaudeCloudRelaySetup.scriptSource, to: script, executable: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Harness

    private struct Request {
        let url: String
        let body: String
        let arguments: [String]
    }

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// A nil value removes the variable from the cloud session's defaults.
    private func execute(_ arguments: [String], payload: [String: Any], environment: [String: String?]) throws -> Run {
        var env = ["PATH": bin.path + ":" + Self.systemPath, "HOME": root.path, "TMPDIR": temporary.path,
                   "KANNU_FAKE_CURL_DIR": calls.path,
                   "CLAUDE_CODE_REMOTE": "true", "CLAUDE_CODE_REMOTE_SESSION_ID": session,
                   "KANNU_RELAY_SECRET": secret, "CLAUDE_PROJECT_DIR": "/home/user/my-repo"]
        for (key, value) in environment { env[key] = value }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   stderr: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// One hook invocation. Whatever happens, it must exit 0 and print nothing: a hook's stdout
    /// becomes part of Claude's context, and a failing hook is shown to the user.
    private func run(_ arguments: [String], payload: [String: Any] = [:], environment: [String: String?] = [:],
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try execute(arguments, payload: payload, environment: environment)
        XCTAssertEqual(result.status, 0, "hook exited \(result.status)", file: file, line: line)
        XCTAssertEqual(result.stdout, "", "a hook's stdout feeds Claude's context", file: file, line: line)
        XCTAssertEqual(result.stderr, "", file: file, line: line)
    }

    private func check(environment: [String: String?] = [:]) throws -> String {
        let result = try execute(["--check"], payload: [:], environment: environment)
        XCTAssertEqual(result.status, 0)
        return result.stdout
    }

    private func requests() throws -> [Request] {
        var found: [Request] = []
        while FileManager.default.fileExists(atPath: calls.appendingPathComponent("\(found.count).body").path) {
            let index = found.count
            let arguments = try String(contentsOf: calls.appendingPathComponent("\(index).args"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let body = try String(contentsOf: calls.appendingPathComponent("\(index).body"), encoding: .utf8)
            found.append(Request(url: arguments.last ?? "", body: body, arguments: arguments))
        }
        return found
    }

    private func fields(_ request: Request) throws -> [String: Any] {
        let parts = request.body.split(separator: " ", maxSplits: 2)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.first, "KC1")
        let payload = parts.last.map(String.init) ?? ""
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    private func states() throws -> [String] {
        try requests().map { try fields($0)["state"] as? String ?? "?" }
    }

    /// What Kannu makes of a captured request, delivered by a relay whose clock reads `now`.
    private func parsed(_ request: Request, now: Date = Date()) throws -> ClaudeCloudRelay.Line {
        let topic = try XCTUnwrap(URL(string: request.url)?.lastPathComponent)
        let line = try JSONSerialization.data(withJSONObject: [
            "id": "x", "time": Int(now.timeIntervalSince1970), "event": "message", "topic": topic, "message": request.body
        ])
        return ClaudeCloudRelay.parse(line: line, credentials: try XCTUnwrap(ClaudeCloudRelay.credentials(secret: secret)),
                                      now: now)
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Plants the script's memory of what it last sent for this session.
    private func seedState(_ values: [String: Any], session: String? = nil) throws {
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateFolder.path)
        try JSONSerialization.data(withJSONObject: values)
            .write(to: stateFolder.appendingPathComponent("\(session ?? self.session).json"))
    }

    // MARK: - It stays out of the way

    func testItDoesNothingOutsideACloudSessionWithoutEvenStartingPython() throws {
        let marker = root.appendingPathComponent("python-ran")
        let noPython = root.appendingPathComponent("no-python", isDirectory: true)
        try FileManager.default.createDirectory(at: noPython, withIntermediateDirectories: true)
        try write("#!/bin/bash\ntouch \"\(marker.path)\"\n", to: noPython.appendingPathComponent("python3"), executable: true)
        let path = noPython.path + ":" + bin.path + ":/usr/bin:/bin"
        try run(["thinking", "UserPromptSubmit"], environment: ["PATH": path, "CLAUDE_CODE_REMOTE": nil])
        try run(["thinking", "UserPromptSubmit"], environment: ["PATH": path, "CLAUDE_CODE_REMOTE": "false"])
        try run(["thinking", "UserPromptSubmit"], environment: ["PATH": path, "KANNU_RELAY_SECRET": nil])
        try run(["thinking", "UserPromptSubmit"], environment: ["PATH": path, "KANNU_RELAY_SECRET": ""])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "a teammate's local session pays one bash test, nothing more")
        XCTAssertTrue(try requests().isEmpty)
    }

    func testAMalformedKeySessionServerOrArgumentSendsNothing() throws {
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_RELAY_SECRET": "abc"])
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_RELAY_SECRET": String(repeating: "g", count: 64)])
        try run(["thinking", "UserPromptSubmit"], environment: ["CLAUDE_CODE_REMOTE_SESSION_ID": nil])
        try run(["thinking", "UserPromptSubmit"], environment: ["CLAUDE_CODE_REMOTE_SESSION_ID": "local_abc"])
        try run(["thinking", "UserPromptSubmit"], environment: ["CLAUDE_CODE_REMOTE_SESSION_ID": "session_a/../b"])
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_RELAY_URL": "http://ntfy.sh"])
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_RELAY_URL": "https://user:pw@ntfy.sh"])
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_RELAY_URL": "https://ntfy.sh/?x=1"])
        try run(["pwned", "UserPromptSubmit"])
        try run(["thinking", "Shell"])
        try run([])
        XCTAssertTrue(try requests().isEmpty)
    }

    func testWithoutPythonOrCurlItStaysSilentAndCheckSaysWhy() throws {
        try run(["thinking", "UserPromptSubmit"], environment: ["PATH": bin.path])
        XCTAssertTrue(try requests().isEmpty)
        XCTAssertTrue(try check(environment: ["PATH": bin.path]).contains("python3 and curl are both required"))
    }

    func testAFailedSendStaysSilentAndIsRetried() throws {
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_FAKE_CURL_EXIT": "7"])
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_FAKE_CURL_STATUS": "429"])
        try run(["thinking", "UserPromptSubmit"])
        try run(["thinking", "UserPromptSubmit"])
        XCTAssertEqual(try requests().count, 3, "an unsent colour is not remembered as sent; a sent one is")
    }

    // MARK: - What leaves the session

    func testEveryCommittedHookProducesAReportKannuAccepts() throws {
        let object = try JSONSerialization.jsonObject(with: Data(ClaudeCloudRelaySetup.hooksJSON().utf8)) as? [String: Any]
        let hooks = try XCTUnwrap(object?["hooks"] as? [String: [[String: Any]]])
        let prefix = "bash \"$CLAUDE_PROJECT_DIR/\(ClaudeCloudRelaySetup.repositoryPath)\" "
        var index = 0
        for (event, groups) in hooks.sorted(by: { $0.key < $1.key }) {
            for group in groups {
                let handler = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
                let command = try XCTUnwrap(handler["command"] as? String)
                XCTAssertTrue(command.hasPrefix(prefix), command)
                let arguments = command.dropFirst(prefix.count).split(separator: " ").map(String.init)
                // A fresh session each time, so no memory of an earlier colour can suppress it.
                let id = "session_Hook\(index)"
                index += 1
                var payload: [String: Any] = ["hook_event_name": event, "tool_name": "Bash"]
                if event == "Notification", let matcher = group["matcher"] as? String {
                    payload["notification_type"] = String(matcher.split(separator: "|")[0])
                }
                try run(arguments, payload: payload, environment: ["CLAUDE_CODE_REMOTE_SESSION_ID": id])
                let request = try XCTUnwrap(try requests().last, command)
                guard case .event(let report) = try parsed(request) else { return XCTFail("rejected: \(command)") }
                XCTAssertEqual(report.sessionID, id)
                XCTAssertEqual(report.event, event)
                XCTAssertEqual(report.state, arguments[0], command)
            }
        }
        XCTAssertEqual(try requests().count, AgentHookLayout.claudeHookEntries.count)
    }

    func testOnlyTheProtocolsFieldsLeaveTheSession() throws {
        let markers = (1...8).map { "PLANTED\($0)MARK" }
        let payload: [String: Any] = [
            "prompt": markers[0],
            "tool_input": ["command": markers[1], "file_path": "/srv/\(markers[2])/a.swift"],
            "tool_response": ["stdout": markers[3]],
            "message": markers[4],
            "transcript_path": "/root/.claude/projects/\(markers[5])/t.jsonl",
            "cwd": "/home/\(markers[6])/elsewhere",
            "tool_name": "Bash"
        ]
        try run(["executing", "PreToolUse"], payload: payload,
                environment: ["CLAUDE_PROJECT_DIR": "/home/\(markers[7])/my-repo"])
        let request = try XCTUnwrap(try requests().first)
        let everything = request.arguments.joined(separator: " ") + request.body
        for marker in markers {
            XCTAssertFalse(everything.contains(marker), "\(marker) left the session")
        }
        XCTAssertFalse(everything.contains(secret), "only keys derived from the secret are ever used")
        let sent = try fields(request)
        XCTAssertEqual(Set(sent.keys), ClaudeCloudRelay.payloadKeys)
        XCTAssertEqual(sent["repo"] as? String, "my-repo", "the folder's name, never its path")
    }

    func testTheRepoIsTheProjectFoldersNameMadeSafe() throws {
        try run(["thinking", "UserPromptSubmit"], environment: ["CLAUDE_PROJECT_DIR": "/home/user/work/my repo (copy)/"])
        try run(["stopped", "Stop"], payload: ["cwd": "/workspace/from-cwd"], environment: ["CLAUDE_PROJECT_DIR": nil])
        let repos = try requests().map { try fields($0)["repo"] as? String }
        XCTAssertEqual(repos, ["my-repo--copy-", "from-cwd"])
    }

    func testAReportIsSignedForTheDerivedTopicAndRoundTripsIntoKannu() throws {
        try run(["awaiting_input", "Notification", "needs_input"], payload: ["notification_type": "permission_prompt"])
        let request = try XCTUnwrap(try requests().first)
        let credentials = try XCTUnwrap(ClaudeCloudRelay.credentials(secret: secret))
        XCTAssertEqual(request.url, "https://ntfy.sh/" + credentials.topic)
        for hardening in ["--proto", "=https", "--max-redirs", "Firebase: no"] {
            XCTAssertTrue(request.arguments.contains(hardening), hardening)
        }
        guard case .event(let report) = try parsed(request) else { return XCTFail("Kannu rejected the script's report") }
        XCTAssertEqual(report.sessionID, session)
        XCTAssertEqual(report.state, "awaiting_input")
        XCTAssertEqual(report.event, "Notification")
        XCTAssertEqual(report.note, "permission_prompt")
        XCTAssertEqual(report.repo, "my-repo")

        let other = String(repeating: "f", count: 64)
        let otherCredentials = try XCTUnwrap(ClaudeCloudRelay.credentials(secret: other))
        let line = try JSONSerialization.data(withJSONObject: [
            "time": Int(Date().timeIntervalSince1970), "event": "message", "topic": otherCredentials.topic,
            "message": request.body
        ])
        XCTAssertEqual(ClaudeCloudRelay.parse(line: line, credentials: otherCredentials), .ignored(.badSignature),
                       "a report replayed onto another user's topic fails their signature check")
    }

    func testACustomRelayIsUsedWhenSet() throws {
        try run(["thinking", "UserPromptSubmit"], environment: ["KANNU_RELAY_URL": "https://relay.example.com/ntfy/"])
        let topic = try XCTUnwrap(ClaudeCloudRelay.credentials(secret: secret)).topic
        XCTAssertEqual(try requests().first?.url, "https://relay.example.com/ntfy/" + topic)
    }

    func testACseSessionIDArrivesInTheFormClaudeAiUses() throws {
        try run(["thinking", "UserPromptSubmit"], environment: ["CLAUDE_CODE_REMOTE_SESSION_ID": "cse_01AbCdEf"])
        guard case .event(let report) = try parsed(try XCTUnwrap(try requests().first)) else { return XCTFail("rejected") }
        XCTAssertEqual(report.sessionID, "session_01AbCdEf")
    }

    func testTimestampsStrictlyIncreaseEvenWhenTheClockDoesNot() throws {
        try run(["thinking", "UserPromptSubmit"])
        try run(["awaiting_input", "PermissionRequest"])
        try run(["stopped", "Stop"])
        let stamps = try requests().map { try XCTUnwrap((try fields($0)["ts"] as? NSNumber)?.int64Value) }
        XCTAssertEqual(stamps.count, 3)
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, 3)

        let ahead = nowMs + 60_000
        try seedState(["key": "red", "event": "Stop", "sent_ms": 0, "ts": ahead], session: "session_Clock")
        try run(["thinking", "UserPromptSubmit"], environment: ["CLAUDE_CODE_REMOTE_SESSION_ID": "session_Clock"])
        XCTAssertEqual((try fields(try XCTUnwrap(try requests().last))["ts"] as? NSNumber)?.int64Value, ahead + 1)
    }

    // MARK: - When it sends

    func testOneColourIsSentOncePerRefreshWindow() throws {
        try run(["thinking", "UserPromptSubmit"])
        try run(["executing", "PreToolUse"], payload: ["tool_name": "Bash"])
        try run(["thinking", "PostToolUse"])
        XCTAssertEqual(try states(), ["thinking"], "thinking and executing are the same green")
    }

    func testAnUnchangedColourIsRefreshedOnceTheWindowPasses() throws {
        let window = Int64(ClaudeCloudRelaySetup.refreshIntervalMs)
        try seedState(["key": "green", "event": "PreToolUse", "sent_ms": nowMs - window + 30_000, "ts": 1])
        try run(["executing", "PreToolUse"], payload: ["tool_name": "Bash"])
        XCTAssertTrue(try requests().isEmpty, "inside the window")
        try seedState(["key": "green", "event": "PreToolUse", "sent_ms": nowMs - window - 1_000, "ts": 1])
        try run(["executing", "PreToolUse"], payload: ["tool_name": "Bash"])
        XCTAssertEqual(try states(), ["executing"], "a long run stays green in Kannu")
    }

    func testAQuestionToolIsNotPaintedGreenByTheGenericHook() throws {
        try run(["executing", "PreToolUse"], payload: ["tool_name": "AskUserQuestion"])
        try run(["executing", "PreToolUse"], payload: ["tool_name": "ExitPlanMode"])
        try run(["executing", "PreToolUse"], payload: ["tool_name": "mcp__x__ask", "tool_input": ["questions": []]])
        XCTAssertTrue(try requests().isEmpty)
        try run(["awaiting_input", "PreToolUse", "gated"], payload: ["tool_name": "AskUserQuestion"])
        XCTAssertEqual(try states(), ["awaiting_input"])
    }

    func testAGreenRightAfterAPromptDoesNotPaintOverIt() throws {
        try run(["awaiting_input", "PermissionRequest"])
        try run(["thinking", "PostToolUse"])
        XCTAssertEqual(try states(), ["awaiting_input"], "a sibling tool call finishing must not hide an open prompt")
        try seedState(["key": "yellow", "event": "PermissionRequest", "sent_ms": nowMs - 3_000, "ts": 1])
        try run(["thinking", "PostToolUse"])
        XCTAssertEqual(try states(), ["awaiting_input", "thinking"], "after the hold, answering the prompt goes green")
    }

    func testASubagentNeverRelightsAFinishedChat() throws {
        try run(["stopped", "Stop"])
        try run(["executing", "PreToolUse"], payload: ["tool_name": "Bash", "agent_id": "agent_1"])
        try run(["thinking", "PostToolUse"], payload: ["agent_id": "agent_1"])
        XCTAssertEqual(try states(), ["stopped"])
        try run(["thinking", "UserPromptSubmit"])
        XCTAssertEqual(try states(), ["stopped", "thinking"], "the chat's own next prompt still does")
    }

    func testACompactOrResumeDoesNotRestartTheCard() throws {
        try run(["idle", "SessionStart"], payload: ["source": "compact"])
        try run(["idle", "SessionStart"], payload: ["source": "resume"])
        XCTAssertTrue(try requests().isEmpty)
        try run(["idle", "SessionStart"], payload: ["source": "startup"])
        XCTAssertEqual(try states(), ["idle"])
    }

    func testAnInterruptedToolMeansStopped() throws {
        try run(["thinking", "PostToolUseFailure"], payload: ["is_interrupt": true])
        XCTAssertEqual(try states(), ["stopped"])
    }

    func testAnIdleNoticeIsItsOwnColour() throws {
        try run(["awaiting_input", "Notification", "needs_input"], payload: ["notification_type": "permission_prompt"])
        try run(["awaiting_input", "Notification", "needs_input"], payload: ["notification_type": "idle_prompt"])
        try run(["awaiting_input", "Notification", "needs_input"], payload: ["notification_type": "something_new"])
        let notes = try requests().map { try fields($0)["note"] as? String }
        XCTAssertEqual(notes, ["permission_prompt", "idle_prompt", ""],
                       "an idle notice ages on the clock in Kannu, so it must not be swallowed as the same yellow")
    }

    // MARK: - Its memory

    func testTheStateFolderIsPrivate() throws {
        try run(["thinking", "UserPromptSubmit"])
        let attributes = try FileManager.default.attributesOfItem(atPath: stateFolder.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testASharedOrRedirectedStateFolderIsNotTrusted() throws {
        try seedState(["key": "green", "event": "UserPromptSubmit", "sent_ms": nowMs, "ts": 1])
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: stateFolder.path)
        try run(["thinking", "UserPromptSubmit"])
        XCTAssertEqual(try requests().count, 1, "a planted memory in a shared folder cannot silence a session")

        try FileManager.default.removeItem(at: stateFolder)
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: stateFolder, withDestinationURL: elsewhere)
        try run(["stopped", "Stop"])
        XCTAssertEqual(try requests().count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty,
                      "nothing is written through a link")
    }

    // MARK: - --check

    func testCheckExplainsAMissingOrMalformedKey() throws {
        XCTAssertTrue(try check(environment: ["KANNU_RELAY_SECRET": nil]).contains("KANNU_RELAY_SECRET: missing"))
        XCTAssertTrue(try check(environment: ["KANNU_RELAY_SECRET": "abc"]).contains("KANNU_RELAY_SECRET: malformed"))
        XCTAssertTrue(try requests().isEmpty)
    }

    func testCheckSendsATestMessageKannuRecognises() throws {
        let output = try check()
        XCTAssertTrue(output.contains("Cloud session: yes"), output)
        XCTAssertTrue(output.contains("Test message: delivered"), output)
        XCTAssertTrue(output.contains("messages left today from this network: 42"), output)
        XCTAssertFalse(output.contains(secret))
        guard case .check(let id, _) = try parsed(try XCTUnwrap(try requests().first)) else {
            return XCTFail("a check must not become a card")
        }
        XCTAssertEqual(id, session)

        let local = try check(environment: ["CLAUDE_CODE_REMOTE": nil, "CLAUDE_CODE_REMOTE_SESSION_ID": nil])
        XCTAssertTrue(local.contains("Cloud session: no"), local)
        guard case .check(let placeholder, _) = try parsed(try XCTUnwrap(try requests().last)) else {
            return XCTFail("a check from a terminal outside the cloud still proves the path")
        }
        XCTAssertEqual(placeholder, "session_Check")
    }

    func testCheckExplainsARefusalAndAUsedUpQuota() throws {
        XCTAssertTrue(try check(environment: ["KANNU_FAKE_CURL_STATUS": "403"])
                        .contains("Network access to Custom and allow ntfy.sh"))
        XCTAssertTrue(try check(environment: ["KANNU_FAKE_CURL_STATUS": "429"]).contains("quota"))
        XCTAssertTrue(try check(environment: ["KANNU_FAKE_CURL_EXIT": "6"]).contains("failed (error: curl exit 6)"))
    }

    // MARK: - The mirror

    func testTheMirrorIsTheScriptKannuHandsOut() throws {
        let mirror = try String(contentsOf: Self.mirrorURL, encoding: .utf8)
        XCTAssertEqual(mirror, ClaudeCloudRelaySetup.scriptSource,
                       "scripts/kannu-cloud-relay.sh drifted from ClaudeCloudRelaySetup.scriptSource")
        XCTAssertTrue(mirror.contains("# " + ClaudeCloudRelaySetup.scriptVersionMarker))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.mirrorURL.path))
    }
}
