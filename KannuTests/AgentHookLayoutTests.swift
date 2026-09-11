//
//  AgentHookLayoutTests.swift
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

/// docs/REGRESSIONS.md entry 6: install, uninstall, the installed check and the migrations must
/// cover the same files. They all read `AgentHookLayout` now; these pin the table and keep paths
/// from creeping back into the installer.
final class AgentHookLayoutTests: XCTestCase {
    private let layout = AgentHookLayout(home: URL(fileURLWithPath: "/Users/u"))

    func testEveryProviderHasAScriptAndAFileInstallAlwaysWrites() {
        var scripts: Set<URL> = []
        var configs: Set<URL> = []
        for provider in AgentHookProvider.allCases {
            let files = layout.files(for: provider)
            XCTAssertEqual(files.script.lastPathComponent, AgentHookLayout.scriptName, "\(provider)")
            XCTAssertTrue(files.script.path.hasPrefix("/Users/u/."), "\(provider) lives in the home folder")
            XCTAssertTrue(scripts.insert(files.script).inserted, "\(provider) has a script of its own")
            XCTAssertTrue(files.configs.contains { $0.write == .always },
                          "\(provider): a fresh install must write a file the installed check can see")
            for config in files.configs {
                XCTAssertTrue(configs.insert(config.url).inserted, "\(config.url.path) belongs to one provider")
                XCTAssertEqual(layout.shape(of: config.url), config.shape)
            }
        }
        XCTAssertNil(layout.shape(of: URL(fileURLWithPath: "/Users/u/.zshrc")))
    }

    func testAntigravityListsAllThreeFilesItReads() {
        let files = layout.files(for: .antigravity)
        XCTAssertEqual(files.configs.map(\.url.path), ["/Users/u/.gemini/config/hooks.json",
                                                       "/Users/u/.gemini/antigravity-ide/hooks.json",
                                                       "/Users/u/.gemini/hooks.json"])
        XCTAssertEqual(files.configs.map(\.write), [.always, .onlyIfPresent, .onlyIfPresent])
        XCTAssertEqual(layout.files(for: .codex).sharedSettings.map(\.lastPathComponent), ["config.toml"])
        XCTAssertEqual(layout.files(for: .vscode).configs.map(\.shape), [.ownFile])
        XCTAssertEqual(layout.files(for: .cursor).configs.map(\.shape), [.flatEntries])
        XCTAssertEqual(layout.files(for: .gemini).configs.map(\.url.path), ["/Users/u/.gemini/settings.json"])
        XCTAssertEqual(layout.files(for: .gemini).script.path, "/Users/u/.gemini/kannu-agent-status.sh",
                       "beside Antigravity's folder, not inside it")
        XCTAssertEqual(layout.files(for: .qwen).configs.map(\.url.path), ["/Users/u/.qwen/settings.json"])
    }

    func testVSCodeTableGainsNotificationButCodexDoesNot() {
        let vscode = AgentHookLayout.vscodeEvents.map(\.event)
        XCTAssertTrue(vscode.contains("Notification"))
        XCTAssertTrue(vscode.contains("SessionEnd"))
        XCTAssertFalse(AgentHookLayout.claudeStyleEvents.map(\.event).contains("Notification"),
                       "Codex validates strictly: its list stays as it was")
        XCTAssertEqual(AgentHookLayout.geminiEvents.map(\.event),
                       ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"])
    }

    func testGeminiMergeWritesOnlyEventKeysAndStripsCleanly() throws {
        let user: [String: Any] = [
            "mcpServers": ["x": ["command": "npx"]],
            "hooks": ["BeforeTool": [["matcher": "write_file", "hooks": [["type": "command", "command": "/usr/local/bin/guard"]]]]],
        ]
        let script = URL(fileURLWithPath: "/Users/u/.gemini/kannu-agent-status.sh")
        let once = AgentHookLayout.mergingKannuGroups(into: user, events: AgentHookLayout.geminiEvents, script: script,
                                                      provider: "gemini", handlerName: AgentHookLayout.handlerName, timeout: 10_000)
        let twice = AgentHookLayout.mergingKannuGroups(into: once, events: AgentHookLayout.geminiEvents, script: script,
                                                       provider: "gemini", handlerName: AgentHookLayout.handlerName, timeout: 10_000)
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice), "merging again changes nothing")
        let hooks = try XCTUnwrap(once["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(AgentHookLayout.geminiEvents.map(\.event)), "only real event names under hooks")
        XCTAssertNotNil(once["mcpServers"], "the rest of the file is kept")
        let beforeTool = try XCTUnwrap(hooks["BeforeTool"] as? [[String: Any]])
        XCTAssertEqual(beforeTool.count, 2, "the user's own hook stays")
        let ours = try XCTUnwrap((beforeTool.last?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(ours["command"] as? String, script.path + " executing gemini BeforeTool")
        XCTAssertEqual(ours["name"] as? String, "kannu-agent-status")
        XCTAssertEqual(ours["timeout"] as? Int, 10_000)
        let stripped = AgentHookLayout.strippingKannuGroups(from: hooks)
        XCTAssertEqual(stripped.keys.sorted(), ["BeforeTool"])
        XCTAssertEqual((stripped["BeforeTool"] as? [[String: Any]])?.count, 1)
    }

    func testQwenMergeRoundTrip() throws {
        let script = URL(fileURLWithPath: "/Users/u/.qwen/kannu-agent-status.sh")
        let merged = AgentHookLayout.mergingKannuGroups(into: [:], events: AgentHookLayout.qwenEvents, script: script,
                                                        provider: "qwen", handlerName: nil, timeout: 10)
        let hooks = try XCTUnwrap(merged["hooks"] as? [String: Any])
        let handler = try XCTUnwrap(((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(handler["command"] as? String, script.path + " awaiting_input qwen PermissionRequest")
        XCTAssertNil(handler["name"])
        XCTAssertTrue(AgentHookLayout.strippingKannuGroups(from: hooks).isEmpty)
    }

    func testOnlyTheOptInCLIsNeedToBePresent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hook-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".gemini/antigravity-ide"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = AgentHookLayout(home: dir)
        XCTAssertFalse(layout.toolIsPresent(.gemini), "Antigravity's folder alone is not Gemini CLI")
        XCTAssertFalse(layout.toolIsPresent(.qwen))
        XCTAssertTrue(layout.toolIsPresent(.claude))
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".gemini/projects.json").path, contents: Data("{}".utf8))
        XCTAssertTrue(layout.toolIsPresent(.gemini))
    }

    /// The installer may name paths only through the layout. Comments and the embedded hook
    /// script (whose sensitive-file tables list agent settings on purpose) are not code paths.
    func testTheInstallerHardCodesNoHookPaths() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kannu/managers/AgentStatus/AgentHookInstaller.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let forbidden = [".cursor/hooks.json", ".cursor/hooks/", ".copilot/hooks", ".codex/hooks.json", ".codex/config.toml",
                         ".claude/settings.json", ".gemini/config/hooks.json", ".gemini/antigravity-ide", ".gemini/hooks.json"]
        var insideScript = false
        for (number, line) in source.components(separatedBy: "\n").enumerated() {
            if insideScript {
                if line == "        \"\"\"" { insideScript = false }
                continue
            }
            if line.hasSuffix("let script = \"\"\"") { insideScript = true; continue }
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") || code.hasPrefix("*") { continue }
            for path in forbidden where code.contains(path) {
                XCTFail("AgentHookInstaller.swift:\(number + 1) names \(path); take it from AgentHookLayout")
            }
        }
    }
}
